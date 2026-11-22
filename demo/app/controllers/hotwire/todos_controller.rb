module Hotwire
  # The server answers each write with a Turbo Stream: only the piece of the
  # page that changed crosses the wire, and the page is never drawn again.
  class TodosController < ApplicationController
    def index
      @todos = Todo.order(created_at: :desc)
    end

    def create
      @todo = Todo.create!(todo_params)
    end

    def update
      @todo = Todo.find(params[:id])
      @todo.update!(state: params[:done] == "1" ? "done" : "open")
    end

    def destroy
      @todo = Todo.find(params[:id])
      @todo.destroy!
    end

    private

    def todo_params
      params.require(:todo).permit(:title)
    end
  end
end
