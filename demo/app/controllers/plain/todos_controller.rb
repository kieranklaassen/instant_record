module Plain
  class TodosController < ApplicationController
    def index
      @todos = Todo.order(created_at: :desc)
    end

    def create
      Todo.create!(todo_params)
      redirect_to plain_root_path
    end

    def update
      Todo.find(params[:id]).update!(state: params[:done] == "1" ? "done" : "open")
      redirect_to plain_root_path
    end

    def destroy
      Todo.find(params[:id]).destroy!
      redirect_to plain_root_path
    end

    private

    def todo_params
      params.require(:todo).permit(:title)
    end
  end
end
