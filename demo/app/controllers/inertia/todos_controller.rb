module Inertia
  # Rails sends the list as props and React draws it. Each write redirects
  # back here, and Inertia swaps the fresh props in under the page.
  class TodosController < ApplicationController
    def index
      render inertia: "Todos/Index", props: {
        todos: Todo.order(created_at: :desc).as_json(only: %i[id title state])
      }
    end

    def create
      Todo.create!(todo_params)
      redirect_to inertia_root_path
    end

    def update
      Todo.find(params[:id]).update!(state: params[:done] == "1" ? "done" : "open")
      redirect_to inertia_root_path
    end

    def destroy
      Todo.find(params[:id]).destroy!
      redirect_to inertia_root_path
    end

    private

    def todo_params
      params.require(:todo).permit(:title)
    end
  end
end
